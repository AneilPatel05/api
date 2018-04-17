require 'radiator'

POWER_TOTAL = 1000.0
POWER_MAX = 100.0
MAX_POST_VOTING_COUNT = 500
MAX_COMMENT_VOTING_COUNT = 200

def get_minimum_power(size)
  minimum = if size < 20
    10
  elsif size < 40
    5
  elsif size < 100
    2
  elsif size  < 200
    1
  else
    0.1
  end
end

# def evenly_distributed_array(size)
#   return Array.new(size, POWER_MAX) if size <= POWER_TOTAL /  POWER_MAX

#   average = POWER_TOTAL / size
#   array = Array.new(size, average)
#   half = (size / 2).floor

#   variation = [POWER_MAX - array[0], array[size - 1] - get_minimum_power(size)].min / half

#   half.times do |i|
#     array[i] = array[i] + variation * (half - i)
#     array[size - i - 1] = array[size - i - 1] - variation * (half - i)
#   end

#   array.map { |n| n.round(2) }
# end

# Ref: https://github.com/Steemhunt/web/issues/102
def natural_distribution_test(size, temperature)
  orders = (1..size - 1).to_a
  exponents = orders.map { |o| Math.exp(o / temperature.to_f) }
  sum = exponents.sum
  softmaxes = exponents.map { |e| e / sum }

  minimum = get_minimum_power(size)
  allocated = Array.new(size, minimum)
  allocated[0] = POWER_MAX
  available = POWER_TOTAL - POWER_MAX - minimum * (size - 1)

  (1..size - 1).each do |i|
    allocated[i] += (available * softmaxes[size -  i - 1])
  end

  allocated
end

def natural_distributed_array(size)
  return Array.new(size, POWER_MAX) if size <= POWER_TOTAL /  POWER_MAX

  minimum = get_minimum_power(size)

  selected = nil
  (1..50).each do |t|
    test_array = natural_distribution_test(size, t)
    if test_array.any? { |n| n > POWER_MAX || n < minimum }
      next
    else
      selected = test_array
      break
    end
  end

  selected.map { |n| n.round(2) }
end

def vote(author, permlink, power)
  sleep(3) # Can only vote once every 3 seconds.
  tx = Radiator::Transaction.new(wif: ENV['STEEMHUNT_POSTING_KEY'])
  vote = {
    type: :vote,
    voter: 'steemhunt',
    author: author,
    permlink: permlink,
    weight: (power * 100).to_i
  }
  tx.operations << vote
  tx.process(true)
end

desc 'Voting bot'
task :voting_bot => :environment do |t, args|
  today = Time.zone.today.to_time
  yesterday = (today - 1.day).to_time

  puts "Voting on daily post begin"
  posts = Post.where('created_at >= ? AND created_at < ?', yesterday, today).
               where(is_active: true).
               order('payout_value DESC').
               limit(MAX_POST_VOTING_COUNT).to_a

  puts "- Total #{posts.size} posts posted on #{yesterday.strftime("%b %e, %Y")}"

  api = Radiator::Api.new
  prosCons = []
  postsToSkip = []
  posts.each_with_index do |post, i|
    puts "-- @#{post.author}/#{post.permlink}"
    votes = api.get_content(post.author, post.permlink)['result']['active_votes']
    puts "----> #{votes.size} active votes returned"
    votes.each do |vote|
      if vote['voter'] == 'steemhunt'
        postsToSkip << post.id
        puts "----> SKIP - Already voted"
      end
    end

    comments = api.get_content_replies(post.author, post.permlink)['result']
    puts "----> #{comments.size} comments returned"
    comments.each do |comment|
      if comment['body'] =~ /pros:/i && comment['body'] =~ /cons:/i
        votes = api.get_content_replies(comment['author'], comment['permlink'])['result']['active_votes']

        shouldSkip = false
        votes.each do |vote|
          if vote['voter'] == 'steemhunt'
            puts "----> SKIP - Already voted P & C: @#{comment['author']}/#{comment['permlink']}"
          end
        end

        unless shouldSkip
          prosCons.push({ author: comment['author'], permlink: comment['permlink'] })
          puts "--> Pros & Cons comment found: @#{comment['author']}/#{comment['permlink']}"
        end
      end
    end

    if prosCons.size >= MAX_COMMENT_VOTING_COUNT
      puts "----> TOO MANY COMMENTS. BREAK"
      break
    end
  end
  puts "- Total #{prosCons.size} Pros & Cons comments found\n\n"

  posts.reject! { |post| postsToSkip.include?(post.id) }
  puts "== VOTING ON #{posts.size} POSTS & #{prosCons.size} COMMENTS =="

  total_count = posts.size + prosCons.size
  puts "- No posts, exit" and return if total_count == 0

  total_vp_used = 0
  vp_distribution = natural_distributed_array(total_count)

  posts.each_with_index do |post, i|
    ranking = i + 1
    voting_power = vp_distribution[ranking - 1]
    total_vp_used += voting_power

    puts "--> Voting on ##{ranking} with #{voting_power}% power: @#{post.author}/#{post.permlink}"
    result = vote(post.author, post.permlink, voting_power)
    puts "----> #{result}"
  end

  prosCons.each_with_index do |comment, i|
    ranking = posts.size + i + 1
    voting_power = get_voting_power(ranking - 1, total_count)
    total_vp_used += voting_power

    puts "--> Voting on ##{ranking} (Pros & Cons) with #{voting_power}% power: @#{comment[:author]}/#{comment[:permlink]}"

    result = vote(comment[:author], comment[:permlink], voting_power)
    puts "----> #{result}"
  end

  vp_left = api.get_accounts(['steemhunt'])['result'][0]['voting_power']
  puts "Votings Finished, #{total_vp_used.round(2)}% VP used, #{vp_left / 100}% VP left"
end